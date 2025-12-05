//
//  CharacterController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 12/5/25.
//

import Foundation
import RealityKit
import Combine

/// Centralized character control system with state machine
/// Handles idle behavior, gestures, movement, and expression
@MainActor
public class CharacterController: ObservableObject {
    public static let shared = CharacterController()
    
    // MARK: - State Machine
    public enum CharacterState {
        case idle
        case speaking
        case moving
        case gesturing
        case thinking
    }
    
    @Published public private(set) var currentState: CharacterState = .idle
    
    // MARK: - Action Types
    public enum Action {
        case pose(String, duration: TimeInterval)
        case move(x: Float, y: Float, z: Float, duration: TimeInterval?)
        case look(target: LookTarget)
        case expression(String)
        case complexMotion(String, duration: TimeInterval?)  // Learned motion
        case idle
    }
    
    public enum LookTarget {
        case user
        case point(x: Float, y: Float, z: Float)
        case forward
    }
    
    // MARK: - Dependencies
    private let modelRenderer = ModelRenderer.shared
    private let ikController = IKController.shared
    private let motionLearner = MotionLearner.shared
    private var idleTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Idle Behavior
    private var idleStartTime: Date?
    private var isIdleAnimating = false
    
    private init() {
        setupIdleBehavior()
    }
    
    // MARK: - Motion Learning API
    
    /// Record a complex motion sequence
    /// - Parameters:
    ///   - motionName: Name to identify this motion
    ///   - frames: Array of motion frames with bone transforms
    public func recordMotion(_ motionName: String, frames: [MotionLearner.MotionFrame]) {
        motionLearner.recordMotion(motionName, frames: frames)
    }
    
    /// Get list of learned motion names
    public func getLearnedMotions() -> [String] {
        return motionLearner.getLearnedMotionNames()
    }
    
    /// Check if a motion has been learned
    public func hasLearnedMotion(_ name: String) -> Bool {
        return motionLearner.hasMotion(name)
    }
    
    // MARK: - Command Parsing
    /// Parse [ACTION:type,params] commands from LLM text
    /// Returns cleaned text and extracted actions
    public func parseActions(from text: String) -> (cleanText: String, actions: [Action]) {
        var cleanText = text
        var actions: [Action] = []
        
        // Match [ACTION:type,params...]
        let pattern = #"\[ACTION:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, [])
        }
        
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { continue }
            
            let content = String(text[contentRange])
            let components = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            
            guard let actionType = components.first else { continue }
            
            // Parse action based on type
            if let action = parseAction(type: String(actionType), params: Array(components.dropFirst())) {
                actions.append(action)
            }
            
            // Remove command from text
            cleanText.removeSubrange(range)
        }
        
        return (cleanText.trimmingCharacters(in: .whitespacesAndNewlines), actions)
    }
    
    private func parseAction(type: String, params: [String]) -> Action? {
        switch type.lowercased() {
        case "pose":
            let poseName = params.first ?? "wave"
            let duration = params.count > 1 ? TimeInterval(params[1]) ?? 2.0 : 2.0
            return .pose(poseName, duration: duration)
            
        case "move":
            guard params.count >= 3,
                  let x = Float(params[0]),
                  let y = Float(params[1]),
                  let z = Float(params[2]) else { return nil }
            let duration = params.count > 3 ? TimeInterval(params[3]) : nil
            return .move(x: x, y: y, z: z, duration: duration)
            
        case "look":
            let target = params.first?.lowercased() ?? "user"
            if target == "user" {
                return .look(target: .user)
            } else if target == "forward" {
                return .look(target: .forward)
            } else if params.count >= 3,
                      let x = Float(params[0]),
                      let y = Float(params[1]),
                      let z = Float(params[2]) {
                return .look(target: .point(x: x, y: y, z: z))
            }
            return nil
            
        case "expression":
            let expressionName = params.first ?? "happy"
            return .expression(expressionName)
            
        case "motion", "complexmotion":
            let motionName = params.first ?? "dance"
            let duration = params.count > 1 ? TimeInterval(params[1]) : nil
            return .complexMotion(motionName, duration: duration)
            
        case "idle":
            return .idle
            
        default:
            return nil
        }
    }
    
    // MARK: - Action Execution
    public func execute(_ action: Action) async {
        switch action {
        case .pose(let name, let duration):
            await executePose(name, duration: duration)
            
        case .move(let x, let y, let z, let duration):
            await executeMove(x: x, y: y, z: z, duration: duration)
            
        case .look(let target):
            await executeLook(target: target)
            
        case .expression(let name):
            await executeExpression(name)
            
        case .complexMotion(let motionName, let duration):
            await executeComplexMotion(motionName, duration: duration)
            
        case .idle:
            await enterIdleState()
        }
    }
    
    // MARK: - State Management
    public func setState(_ state: CharacterState) {
        currentState = state
        
        switch state {
        case .idle:
            startIdleBehavior()
        case .speaking, .moving, .gesturing, .thinking:
            stopIdleBehavior()
        }
    }
    
    // MARK: - Idle Behavior
    private func setupIdleBehavior() {
        // Start idle animations when state becomes idle
        $currentState
            .sink { [weak self] state in
                if state == .idle {
                    self?.startIdleBehavior()
                } else {
                    self?.stopIdleBehavior()
                }
            }
            .store(in: &cancellables)
    }
    
    private func startIdleBehavior() {
        guard !isIdleAnimating else { return }
        isIdleAnimating = true
        idleStartTime = Date()
        
        // Schedule subtle idle animations
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.performIdleAnimation()
            }
        }
    }
    
    private func stopIdleBehavior() {
        isIdleAnimating = false
        idleTimer?.invalidate()
        idleTimer = nil
    }
    
    private func performIdleAnimation() async {
        guard let entity = modelRenderer.modelEntity else { return }
        
        // Use IK procedural motion instead of simple animations
        let breathingIntensity = ikController.getBreathingIntensity()
        let swayOffset = ikController.getSwayOffset()
        
        // Apply breathing to model scale
        let originalScale = entity.scale
        let breatheScale = SIMD3<Float>(
            x: originalScale.x * (1.0 + breathingIntensity * 0.01),
            y: originalScale.y * (1.0 + breathingIntensity * 0.005),
            z: originalScale.z * (1.0 + breathingIntensity * 0.01)
        )
        entity.scale = breatheScale
        
        // Apply subtle sway
        let swayedPosition = entity.position + SIMD3<Float>(swayOffset, 0, 0)
        entity.position = swayedPosition
        
        // Check blink state
        if ikController.shouldBlink() {
            modelRenderer.setBlendShape(name: "eyesClosed", value: 1.0)
        } else {
            modelRenderer.setBlendShape(name: "eyesClosed", value: 0.0)
        }
    }
    
    // MARK: - Action Implementations
    private func executePose(_ name: String, duration: TimeInterval) async {
        setState(.gesturing)
        
        // Map pose names to blendshape configurations
        let poseBlendshapes: [String: [String: Float]] = [
            "wave": ["pose_wave": 1.0],
            "happy": ["smile": 0.8, "eyesClosed": 0.3],
            "surprised": ["eyesWide": 1.0, "mouthOpen": 0.7],
            "think": ["eyesSquint": 0.5, "browDown": 0.3],
            "sad": ["browDown": 0.7, "mouthFrown": 0.6],
            "point": ["pose_point": 1.0]
        ]
        
        if let blendshapes = poseBlendshapes[name.lowercased()] {
            // Apply blendshapes
            for (shapeName, weight) in blendshapes {
                modelRenderer.setBlendShape(name: shapeName, value: weight)
            }
            
            // Hold pose for duration
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            
            // Reset blendshapes
            for (shapeName, _) in blendshapes {
                modelRenderer.setBlendShape(name: shapeName, value: 0.0)
            }
        }
        
        setState(.idle)
    }
    
    private func executeMove(x: Float, y: Float, z: Float, duration: TimeInterval?) async {
        setState(.moving)
        
        guard let entity = modelRenderer.modelEntity else {
            setState(.idle)
            return
        }
        
        let targetPosition = SIMD3<Float>(x, y, z)
        let moveDuration = duration ?? 1.0
        
                // Use IK to move right arm to target position\n        ikController.moveLimbTo(\n            ikController.rightArm,\n            position: targetPosition,\n            duration: moveDuration,\n            modelEntity: entity\n        )
        
        // Also move the entity slightly towards target
        let currentPos = entity.position
        let direction = simd_normalize(targetPosition - currentPos)
        let moveDistance = min(0.3, simd_distance(currentPos, targetPosition))
        let newPos = currentPos + direction * moveDistance
        
        entity.move(to: Transform(scale: entity.scale, rotation: entity.orientation, translation: newPos), relativeTo: entity.parent, duration: moveDuration)
        
        try? await Task.sleep(nanoseconds: UInt64(moveDuration * 1_000_000_000))
        setState(.idle)
    }
    
    private func executeLook(target: LookTarget) async {
        guard let entity = modelRenderer.modelEntity else { return }
        
        let targetDirection: SIMD3<Float>
        
        switch target {
        case .user:
            // Look at camera/user (assumed to be at origin)
            targetDirection = -entity.position
        case .point(let x, let y, let z):
            targetDirection = SIMD3<Float>(x, y, z) - entity.position
        case .forward:
            targetDirection = SIMD3<Float>(0, 0, 1)
        }
        
        // Update IK look direction for procedural head control
        ikController.setLookDirection(normalize(targetDirection))
        
        // Calculate rotation to look at target and apply to head
        let normalized = normalize(targetDirection)
        let targetRotation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: normalized)
        
        if let headBone = entity.findChild(named: "Armature.Head") ?? entity.findChild(named: "Head") {
            headBone.move(to: Transform(scale: headBone.scale, rotation: targetRotation, translation: headBone.position), relativeTo: headBone.parent, duration: 0.5)
        } else {
            // Fallback: rotate entire entity
            entity.move(to: Transform(scale: entity.scale, rotation: targetRotation, translation: entity.position), relativeTo: entity.parent, duration: 0.5)
        }
    }
    
    private func executeExpression(_ name: String) async {
        // Map expression names to blendshapes
        let expressionBlendshapes: [String: [String: Float]] = [
            "happy": ["smile": 0.9],
            "sad": ["mouthFrown": 0.8],
            "surprised": ["eyesWide": 1.0, "mouthOpen": 0.8],
            "angry": ["browDown": 0.9, "mouthFrown": 0.5],
            "blink": ["eyesClosed": 1.0],
            "think": ["eyesSquint": 0.4, "browUp": 0.3]
        ]
        
        if let blendshapes = expressionBlendshapes[name.lowercased()] {
            for (shapeName, weight) in blendshapes {
                modelRenderer.setBlendShape(name: shapeName, value: weight)
            }
            
            // Hold expression briefly
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            
            // Reset to neutral
            for (shapeName, _) in blendshapes {
                modelRenderer.setBlendShape(name: shapeName, value: 0.0)
            }
        }
    }
    
    private func executeComplexMotion(_ motionName: String, duration: TimeInterval?) async {
        setState(.gesturing)
        
        guard let entity = modelRenderer.modelEntity else {
            setState(.idle)
            return
        }
        
        // Check if motion has been learned
        if motionLearner.hasMotion(motionName) {
            // Play the learned motion
            motionLearner.playMotion(motionName, on: entity, duration: duration)
            
            let motionDuration = duration ?? (motionLearner.getMotion(motionName)?.duration ?? 2.0)
            try? await Task.sleep(nanoseconds: UInt64(motionDuration * 1_000_000_000))
            motionLearner.stopMotion(motionName)
        } else {
            // Motion not learned yet - fallback to simple pose
            print("[CharacterController] Motion '\(motionName)' not learned, using fallback")
            await executePose(motionName, duration: duration ?? 2.0)
        }
        
        setState(.idle)
    }
    
    private func enterIdleState() async {
        setState(.idle)
    }
}

// MARK: - Extension: Helper to find bones
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
