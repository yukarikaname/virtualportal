//
//  CharacterAutoController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 12/5/25.
//

import Foundation
import RealityKit

/// Self-control system for autonomous character skeleton and blendshape management
/// Allows the character to move and express without LLM input
@MainActor
public class CharacterAutoController {
    public static let shared = CharacterAutoController()
    
    // MARK: - Dependencies
    private let modelRenderer = ModelRenderer.shared
    private let ikController = IKController.shared
    private let characterController = CharacterController.shared
    
    // MARK: - Auto-Motion State
    private var autoMotionTimer: Timer?
    private var currentMotionSequence: MotionSequence?
    private var motionStartTime: Date?
    
    // MARK: - Blendshape Automation
    private var blendshapeAnimationTimers: [String: Timer] = [:]
    private var currentBlendshapeValues: [String: Float] = [:]
    
    // MARK: - Motion Sequence
    public struct MotionSequence {
        public let name: String
        public let actions: [MotionAction]
        public let loop: Bool
        public let duration: TimeInterval
        
        public init(name: String, actions: [MotionAction], loop: Bool = false, duration: TimeInterval = 0) {
            self.name = name
            self.actions = actions
            self.loop = loop
            self.duration = duration
        }
    }
    
    public enum MotionAction {
        /// Move IK chain to target position
        case moveChain(chainName: String, targetX: Float, targetY: Float, targetZ: Float, duration: TimeInterval)
        
        /// Animate blendshape from start to end value
        case blendshapeTransition(name: String, startValue: Float, endValue: Float, duration: TimeInterval, easeType: EaseType)
        
        /// Hold position for duration
        case wait(TimeInterval)
        
        /// Look at specific direction
        case lookAt(x: Float, y: Float, z: Float, duration: TimeInterval)
        
        /// Trigger a learned motion
        case playLearnedMotion(name: String, duration: TimeInterval?)
    }
    
    public enum EaseType {
        case linear
        case easeInOut
        case easeIn
        case easeOut
    }
    
    // MARK: - Predefined Motion Sequences
    
    /// Create a wave gesture motion
    public func createWaveMotion() -> MotionSequence {
        return MotionSequence(
            name: "wave",
            actions: [
                .moveChain(chainName: "rightArm", targetX: 0.3, targetY: 0.5, targetZ: 0, duration: 0.5),
                .wait(0.3),
                .moveChain(chainName: "rightArm", targetX: 0.2, targetY: 0.4, targetZ: 0, duration: 0.3),
                .wait(0.2),
                .moveChain(chainName: "rightArm", targetX: 0.3, targetY: 0.5, targetZ: 0, duration: 0.3),
            ],
            loop: false,
            duration: 1.3
        )
    }
    
    /// Create a nod gesture motion
    public func createNodMotion() -> MotionSequence {
        return MotionSequence(
            name: "nod",
            actions: [
                .lookAt(x: 0, y: -0.3, z: 0, duration: 0.3),
                .wait(0.2),
                .lookAt(x: 0, y: 0, z: 0, duration: 0.3),
            ],
            loop: false,
            duration: 0.8
        )
    }
    
    /// Create a shake gesture motion
    public func createShakeMotion() -> MotionSequence {
        return MotionSequence(
            name: "shake",
            actions: [
                .lookAt(x: 0.2, y: 0, z: 0, duration: 0.2),
                .wait(0.1),
                .lookAt(x: -0.2, y: 0, z: 0, duration: 0.2),
                .wait(0.1),
                .lookAt(x: 0.2, y: 0, z: 0, duration: 0.2),
                .wait(0.1),
                .lookAt(x: 0, y: 0, z: 0, duration: 0.2),
            ],
            loop: false,
            duration: 1.1
        )
    }
    
    /// Create a thinking pose with blinking
    public func createThinkingMotion() -> MotionSequence {
        return MotionSequence(
            name: "thinking",
            actions: [
                .blendshapeTransition(name: "eyeBlinkLeft", startValue: 0, endValue: 1, duration: 0.15, easeType: .easeInOut),
                .blendshapeTransition(name: "eyeBlinkRight", startValue: 0, endValue: 1, duration: 0.15, easeType: .easeInOut),
                .wait(0.2),
                .blendshapeTransition(name: "eyeBlinkLeft", startValue: 1, endValue: 0, duration: 0.15, easeType: .easeInOut),
                .blendshapeTransition(name: "eyeBlinkRight", startValue: 1, endValue: 0, duration: 0.15, easeType: .easeInOut),
            ],
            loop: true,
            duration: 0.65
        )
    }
    
    /// Create a smile expression
    public func createSmileExpression() -> MotionSequence {
        return MotionSequence(
            name: "smile",
            actions: [
                .blendshapeTransition(name: "mouthSmile", startValue: 0, endValue: 1, duration: 0.3, easeType: .easeInOut),
                .blendshapeTransition(name: "eyeSquintLeft", startValue: 0, endValue: 0.5, duration: 0.3, easeType: .easeInOut),
                .blendshapeTransition(name: "eyeSquintRight", startValue: 0, endValue: 0.5, duration: 0.3, easeType: .easeInOut),
            ],
            loop: false,
            duration: 0.3
        )
    }
    
    /// Create a surprised expression
    public func createSurpriseExpression() -> MotionSequence {
        return MotionSequence(
            name: "surprise",
            actions: [
                .blendshapeTransition(name: "eyeWideLeft", startValue: 0, endValue: 1, duration: 0.2, easeType: .easeOut),
                .blendshapeTransition(name: "eyeWideRight", startValue: 0, endValue: 1, duration: 0.2, easeType: .easeOut),
                .blendshapeTransition(name: "mouthOpen", startValue: 0, endValue: 0.8, duration: 0.2, easeType: .easeOut),
            ],
            loop: false,
            duration: 0.2
        )
    }
    
    // MARK: - Motion Control
    
    /// Play a motion sequence
    public func playMotionSequence(_ sequence: MotionSequence) {
        stopMotionSequence()
        
        currentMotionSequence = sequence
        motionStartTime = Date()
        
        executeMotionSequence(sequence, startIndex: 0)
    }
    
    /// Stop the current motion sequence
    public func stopMotionSequence() {
        autoMotionTimer?.invalidate()
        autoMotionTimer = nil
        currentMotionSequence = nil
        motionStartTime = nil
        
        // Reset all blendshape animations
        blendshapeAnimationTimers.forEach { $0.value.invalidate() }
        blendshapeAnimationTimers.removeAll()
    }
    public func playGesture(_ gestureName: String) {
        let sequence: MotionSequence
        
        switch gestureName.lowercased() {
        case "wave":
            sequence = createWaveMotion()
        case "nod":
            sequence = createNodMotion()
        case "shake":
            sequence = createShakeMotion()
        case "smile":
            sequence = createSmileExpression()
        case "surprise":
            sequence = createSurpriseExpression()
        case "thinking":
            sequence = createThinkingMotion()
        default:
            print("[CharacterAutoController] Unknown gesture: \(gestureName)")
            return
        }
        
        playMotionSequence(sequence)
    }
    
    /// Set a blendshape value directly
    public func setBlendShape(_ name: String, value: Float, animated: Bool = false, duration: TimeInterval = 0.3) {
        let clampedValue = max(0, min(1, value))
        
        if animated {
            animateBlendShape(name, from: currentBlendshapeValues[name] ?? 0, to: clampedValue, duration: duration)
        } else {
            modelRenderer.setBlendShape(name: name, value: clampedValue)
            currentBlendshapeValues[name] = clampedValue
        }
    }
    
    /// Move a joint chain to target position
    public func moveJointChain(_ chainName: String, to position: SIMD3<Float>, duration: TimeInterval = 0.5) {
        guard let modelEntity = modelRenderer.modelEntity else {
            print("[CharacterAutoController] No model entity available")
            return
        }
        
        // Get the appropriate chain
        let chain: IKController.JointChain?
        switch chainName.lowercased() {
        case "rightarm":
            chain = ikController.rightArm
        case "leftarm":
            chain = ikController.leftArm
        case "head":
            chain = ikController.head
        case "rightleg":
            chain = ikController.rightLeg
        case "leftleg":
            chain = ikController.leftLeg
        default:
            print("[CharacterAutoController] Unknown chain: \(chainName)")
            return
        }
        
        if let chain = chain {
            ikController.moveLimbTo(chain, position: position, duration: duration, modelEntity: modelEntity)
        }
    }
    
    /// Look at a specific direction
    public func lookAtDirection(_ direction: SIMD3<Float>) {
        ikController.setLookDirection(direction)
    }
    
    // MARK: - Private Motion Execution
    
    private func executeMotionSequence(_ sequence: MotionSequence, startIndex: Int) {
        guard startIndex < sequence.actions.count else {
            // Sequence complete
            if sequence.loop {
                // Restart from beginning
                executeMotionSequence(sequence, startIndex: 0)
            } else {
                currentMotionSequence = nil
            }
            return
        }
        
        let action = sequence.actions[startIndex]
        let nextIndex = startIndex + 1
        
        switch action {
        case .wait(let duration):
            scheduleNextAction(sequence, nextIndex: nextIndex, delay: duration)
            
        case .moveChain(let chainName, let x, let y, let z, let duration):
            let position = SIMD3<Float>(x, y, z)
            moveJointChain(chainName, to: position, duration: duration)
            scheduleNextAction(sequence, nextIndex: nextIndex, delay: duration)
            
        case .blendshapeTransition(let name, let start, let end, let duration, let easeType):
            animateBlendShape(name, from: start, to: end, duration: duration, easeType: easeType)
            scheduleNextAction(sequence, nextIndex: nextIndex, delay: duration)
            
        case .lookAt(let x, let y, let z, let duration):
            let direction = SIMD3<Float>(x, y, z)
            lookAtDirection(direction)
            scheduleNextAction(sequence, nextIndex: nextIndex, delay: duration)
            
        case .playLearnedMotion(let motionName, let duration):
            guard let modelEntity = modelRenderer.modelEntity else {
                scheduleNextAction(sequence, nextIndex: nextIndex, delay: 0)
                return
            }
            
            let motionDuration = duration ?? 1.0
            // Note: This assumes MotionLearner has a public play method
            // Adjust as needed based on actual MotionLearner API
            scheduleNextAction(sequence, nextIndex: nextIndex, delay: motionDuration)
        }
    }
    
    private func scheduleNextAction(_ sequence: MotionSequence, nextIndex: Int, delay: TimeInterval) {
        autoMotionTimer?.invalidate()
        autoMotionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.executeMotionSequence(sequence, startIndex: nextIndex)
        }
    }
    
    private func animateBlendShape(_ name: String, from startValue: Float, to endValue: Float, duration: TimeInterval, easeType: EaseType = .easeInOut) {
        // Cancel existing animation for this blendshape
        blendshapeAnimationTimers[name]?.invalidate()
        
        let startTime = Date()
        let clampedStart = max(0, min(1, startValue))
        let clampedEnd = max(0, min(1, endValue))
        
        currentBlendshapeValues[name] = clampedStart
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] timer in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(1.0, elapsed / duration)
            
            // Apply easing
            let easedProgress = self?.applyEasing(progress, type: easeType) ?? progress
            
            let currentValue = clampedStart + (clampedEnd - clampedStart) * Float(easedProgress)
            self?.modelRenderer.setBlendShape(name: name, value: currentValue)
            self?.currentBlendshapeValues[name] = currentValue
            
            if progress >= 1.0 {
                timer.invalidate()
                self?.blendshapeAnimationTimers.removeValue(forKey: name)
            }
        }
        
        blendshapeAnimationTimers[name] = timer
    }
    
    private func applyEasing(_ progress: Double, type: EaseType) -> Double {
        switch type {
        case .linear:
            return progress
        case .easeInOut:
            return progress < 0.5
                ? 2 * progress * progress
                : -1 + (4 - 2 * progress) * progress
        case .easeIn:
            return progress * progress
        case .easeOut:
            return 1 - (1 - progress) * (1 - progress)
        }
    }
}
