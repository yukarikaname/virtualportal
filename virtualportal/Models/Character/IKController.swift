//
//  IKController.swift
//  virtualportal
//
//  Created by Yukari Kaname on 12/5/25.
//
// MARK: - Inverse Kinematics & Procedural Animation Controller
// 
// Supports multiple bone naming conventions:
// 1. English (Blender/Armature standard): "Armature.RightShoulder", "Armature.LeftElbow", etc.
// 2. MMD/Japanese (Vocaloid models): "右肩", "左ひじ", "頭", etc.
// 3. Auto-Detection: Automatically detects the model's naming convention on first load
//
// Usage:
//   1. When a model is loaded, call: IKController.shared.autoDetectBoneNaming(from: modelEntity)
//   2. The IK solver will automatically use the correct bone names
//   3. Use public chains: ikController.rightArm, ikController.leftArm, ikController.head
//
// Supported Operations:
//   - solveIK() - Solve inverse kinematics for limb targeting
//   - moveLimbTo() - Animate limb to target position
//   - setLookDirection() - Control head look direction
//   - getBreathingIntensity() - Procedural breathing (idle animation)
//   - getSwayOffset() - Procedural body sway (idle animation)
//   - shouldBlink() - Procedural blinking (idle animation)
//
// Bone Mapping Example:
//   English: Armature.RightShoulder, Armature.RightElbow, Armature.RightWrist
//   Japanese: 右肩, 右ひじ, 右手首
//   Both map to the same StandardBoneName.rightShoulder enum value internally
//

import Foundation
import RealityKit

// MARK: - Standard Bone Names (English)
public enum StandardBoneName: String, CaseIterable {
    case rightShoulder = "RightShoulder"
    case rightElbow = "RightElbow"
    case rightWrist = "RightWrist"
    case leftShoulder = "LeftShoulder"
    case leftElbow = "LeftElbow"
    case leftWrist = "LeftWrist"
    case neck = "Neck"
    case head = "Head"
    case spine = "Spine"
    case hips = "Hips"
    case rightHip = "RightHip"
    case rightKnee = "RightKnee"
    case rightAnkle = "RightAnkle"
    case leftHip = "LeftHip"
    case leftKnee = "LeftKnee"
    case leftAnkle = "LeftAnkle"
}

/// Inverse Kinematics controller for procedural character animation
/// Handles limb IK solving, procedural motion (breathing, swaying, blinking)
/// Supports multiple bone naming conventions (English, Japanese MMD)
@MainActor
public class IKController {
    public static let shared = IKController()
    
    // MARK: - Bone Naming Conventions
    /// Maps standard English names to actual bone names in the model
    private var boneNameMap: [String: String] = [:]
    
    /// Supported naming conventions
    public enum BoneNamingConvention {
        case english    // Standard: "Armature.RightShoulder"
        case mmd        // MMD/Japanese: "右肩" (right shoulder)
        case autoDetect // Auto-detect from model
    }
    
    private var namingConvention: BoneNamingConvention = .autoDetect
    
    // MARK: - MMD/Japanese Bone Names
    private let mmdBoneNames: [StandardBoneName: String] = [
        .rightShoulder: "右肩",
        .rightElbow: "右ひじ",
        .rightWrist: "右手首",
        .leftShoulder: "左肩",
        .leftElbow: "左ひじ",
        .leftWrist: "左手首",
        .neck: "首",
        .head: "頭",
        .spine: "脊椎",
        .hips: "下半身",
        .rightHip: "右足",
        .rightKnee: "右ひざ",
        .rightAnkle: "右足首",
        .leftHip: "左足",
        .leftKnee: "左ひざ",
        .leftAnkle: "左足首"
    ]
    
    // MARK: - Joint Chain Definitions
    public struct JointChain {
        public let name: String
        public let standardNames: [StandardBoneName]  // Use standard enum names
        public let constraints: JointConstraints?
        
        public init(name: String, standardNames: [StandardBoneName], constraints: JointConstraints? = nil) {
            self.name = name
            self.standardNames = standardNames
            self.constraints = constraints
        }
        
        /// Get actual bone names using the provided naming convention
        func getBoneNames(with convention: BoneNamingConvention, using nameMap: [String: String]) -> [String] {
            return standardNames.map { standard in
                // First check if there's a direct mapping
                if let mapped = nameMap[standard.rawValue] {
                    return mapped
                }
                
                // Otherwise, construct the name based on convention
                switch convention {
                case .english:
                    return "Armature." + standard.rawValue
                case .mmd:
                    return standard.rawValue  // Use Japanese names directly
                case .autoDetect:
                    // Default to English with Armature prefix
                    return "Armature." + standard.rawValue
                }
            }
        }
    }
    
    public struct JointConstraints {
        public let minAngles: SIMD3<Float>  // Min rotation in degrees
        public let maxAngles: SIMD3<Float>  // Max rotation in degrees
        public let maxBendAngle: Float?     // For single-axis constraints like elbows
        
        public init(minAngles: SIMD3<Float>, maxAngles: SIMD3<Float>, maxBendAngle: Float? = nil) {
            self.minAngles = minAngles
            self.maxAngles = maxAngles
            self.maxBendAngle = maxBendAngle
        }
    }
    
    // MARK: - Joint Chain Definitions
    private var rightArmChain: JointChain!
    private var leftArmChain: JointChain!
    private var headChain: JointChain!
    private var rightLegChain: JointChain!
    private var leftLegChain: JointChain!
    
    // MARK: - IK Solver Parameters
    private let maxIterations = 10
    private let convergenceThreshold: Float = 0.001
    private let chainStepSize: Float = 0.1
    
    // MARK: - Procedural Motion State
    private var breathingPhase: Float = 0
    private var lookDirection: SIMD3<Float> = [0, 0, 1]
    private var blinkPhase: Float = 0
    private var swayPhase: Float = 0
    
    // MARK: - Timers
    private var procedureTimer: Timer?
    private let procedureUpdateInterval: TimeInterval = 0.016  // ~60fps
    
    private init() {
        initializeChains()
        startProceduralMotion()
    }
    
    deinit {
        // Timer will be cleaned up automatically
    }
    
    // MARK: - Initialization
    
    private func initializeChains() {
        let armConstraints = JointConstraints(
            minAngles: [-90, -180, -90],
            maxAngles: [90, 0, 90],
            maxBendAngle: 150
        )
        
        rightArmChain = JointChain(
            name: "RightArm",
            standardNames: [.rightShoulder, .rightElbow, .rightWrist],
            constraints: armConstraints
        )
        
        leftArmChain = JointChain(
            name: "LeftArm",
            standardNames: [.leftShoulder, .leftElbow, .leftWrist],
            constraints: armConstraints
        )
        
        headChain = JointChain(
            name: "Head",
            standardNames: [.neck, .head]
        )
        
        rightLegChain = JointChain(
            name: "RightLeg",
            standardNames: [.rightHip, .rightKnee, .rightAnkle]
        )
        
        leftLegChain = JointChain(
            name: "LeftLeg",
            standardNames: [.leftHip, .leftKnee, .leftAnkle]
        )
    }
    
    /// Auto-detect bone naming convention from the model
    /// Returns true if detection was successful
    public func autoDetectBoneNaming(from modelEntity: ModelEntity) -> Bool {
        // Try English convention first
        let englishBones = testNamingConvention(.english, modelEntity: modelEntity)
        if englishBones > 10 {
            namingConvention = .english
            print("[IK] Detected English bone naming convention")
            buildBoneNameMap(for: .english)
            return true
        }
        
        // Try MMD convention
        let mmdBones = testNamingConvention(.mmd, modelEntity: modelEntity)
        if mmdBones > 10 {
            namingConvention = .mmd
            print("[IK] Detected MMD/Japanese bone naming convention")
            buildBoneNameMap(for: .mmd)
            return true
        }
        
        // Fallback to English
        print("[IK] Could not auto-detect naming convention, defaulting to English")
        namingConvention = .english
        buildBoneNameMap(for: .english)
        return false
    }
    
    /// Test how many bones match a given naming convention
    private func testNamingConvention(_ convention: BoneNamingConvention, modelEntity: ModelEntity) -> Int {
        var matchCount = 0
        
        for standardBone in StandardBoneName.allCases {
            let boneName: String
            
            switch convention {
            case .english:
                boneName = "Armature." + standardBone.rawValue
            case .mmd:
                boneName = mmdBoneNames[standardBone] ?? standardBone.rawValue
            case .autoDetect:
                continue
            }
            
            if modelEntity.findChild(named: boneName) != nil {
                matchCount += 1
            }
        }
        
        return matchCount
    }
    
    /// Build the bone name map for the detected naming convention
    private func buildBoneNameMap(for convention: BoneNamingConvention) {
        boneNameMap.removeAll()
        
        for standardBone in StandardBoneName.allCases {
            let actualName: String
            
            switch convention {
            case .english:
                actualName = "Armature." + standardBone.rawValue
            case .mmd:
                actualName = mmdBoneNames[standardBone] ?? standardBone.rawValue
            case .autoDetect:
                actualName = "Armature." + standardBone.rawValue
            }
            
            boneNameMap[standardBone.rawValue] = actualName
        }
    }
    
    /// Get a bone name using the detected convention
    public func getBoneName(_ standardName: StandardBoneName) -> String {
        return boneNameMap[standardName.rawValue] ?? ("Armature." + standardName.rawValue)
    }
    
    // MARK: - Public IK Methods
    
    /// Solve IK for a chain to reach a target position
    public func solveIK(chain: JointChain, targetPosition: SIMD3<Float>, modelEntity: ModelEntity) {
        let boneNames = chain.getBoneNames(with: namingConvention, using: boneNameMap)
        var currentPosition = getEndEffectorPosition(boneNames: boneNames, modelEntity: modelEntity)
        
        for iteration in 0..<maxIterations {
            let distance = simd_distance(currentPosition, targetPosition)
            if distance < convergenceThreshold {
                print("[IK] Converged in \(iteration) iterations for \(chain.name)")
                return
            }
            
            // Work backwards through joint chain (FABRIK-style)
            for jointIndex in stride(from: boneNames.count - 1, through: 0, by: -1) {
                adjustJoint(
                    at: jointIndex,
                    boneNames: boneNames,
                    towards: targetPosition,
                    modelEntity: modelEntity,
                    constraints: chain.constraints
                )
            }
            
            currentPosition = getEndEffectorPosition(boneNames: boneNames, modelEntity: modelEntity)
        }
        
        print("[IK] Max iterations reached for \(chain.name)")
    }
    
    /// Move a limb to a specific position with procedural smoothing
    public func moveLimbTo(_ chain: JointChain, position: SIMD3<Float>, duration: TimeInterval = 0.5, modelEntity: ModelEntity) {
        let startTime = Date()
        let boneNames = chain.getBoneNames(with: namingConvention, using: boneNameMap)
        let startPosition = getEndEffectorPosition(boneNames: boneNames, modelEntity: modelEntity)
        
        var motionTimer: Timer?
        motionTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            let elapsed = Date().timeIntervalSince(startTime)
            let progress = min(1.0, Float(elapsed / duration))
            
            // Easing function (ease-in-out cubic)
            let easeProgress: Float
            if progress < 0.5 {
                easeProgress = 4 * progress * progress * progress
            } else {
                easeProgress = 1 - pow(-2 * progress + 2, 3) / 2
            }
            
            let currentTarget = simd_mix(startPosition, position, simd_float3(repeating: easeProgress))
            self?.solveIK(chain: chain, targetPosition: currentTarget, modelEntity: modelEntity)
            
            if progress >= 1.0 {
                motionTimer?.invalidate()
            }
        }
    }
    
    /// Set the direction the character should look
    public func setLookDirection(_ direction: SIMD3<Float>) {
        lookDirection = simd_normalize(direction)
    }
    
    // MARK: - Procedural Motion
    
    /// Start procedural idle animations
    public func startProceduralMotion() {
        procedureTimer = Timer.scheduledTimer(withTimeInterval: procedureUpdateInterval, repeats: true) { [weak self] _ in
            self?.updateProceduralMotion()
        }
    }
    
    /// Stop procedural animations
    public func stopProceduralMotion() {
        procedureTimer?.invalidate()
        procedureTimer = nil
    }
    
    private func updateProceduralMotion() {
        let deltaTime: Float = 0.016
        
        // Update breathing phase (slow oscillation)
        breathingPhase = fmod(breathingPhase + deltaTime * 0.5, Float.pi * 2)
        
        // Update sway phase (slower oscillation)
        swayPhase = fmod(swayPhase + deltaTime * 0.2, Float.pi * 2)
        
        // Update blink phase (discrete blinks)
        blinkPhase = fmod(blinkPhase + deltaTime, Float.pi * 2)
    }
    
    /// Get current breathing intensity (0-1)
    public func getBreathingIntensity() -> Float {
        return (sin(breathingPhase) + 1) / 2  // Map from [-1,1] to [0,1]
    }
    
    /// Get current sway offset for idle motion
    public func getSwayOffset() -> Float {
        return sin(swayPhase) * 0.05  // ±5cm sway
    }
    
    /// Check if character should blink
    public func shouldBlink() -> Bool {
        let blinkCycle = fmod(blinkPhase, Float.pi * 2)
        let blinkDuration: Float = 0.15  // 150ms blink
        let blinkInterval: Float = 3.0   // Blink every 3 seconds
        
        let timeInCycle = fmod(blinkCycle, blinkInterval)
        return timeInCycle < blinkDuration
    }
    
    // MARK: - Exposed Joint Chains for External Access
    
    public var rightArm: JointChain { rightArmChain }
    public var leftArm: JointChain { leftArmChain }
    public var head: JointChain { headChain }
    public var rightLeg: JointChain { rightLegChain }
    public var leftLeg: JointChain { leftLegChain }
    
    // MARK: - Private IK Helpers
    
    private func getEndEffectorPosition(boneNames: [String], modelEntity: ModelEntity) -> SIMD3<Float> {
        guard let lastBoneName = boneNames.last else { return [0, 0, 0] }
        
        if let endEffector = modelEntity.findChild(named: lastBoneName) {
            return endEffector.position + (endEffector.parent?.position ?? [0, 0, 0])
        }
        
        return [0, 0, 0]
    }
    
    private func adjustJoint(at index: Int, boneNames: [String], towards target: SIMD3<Float>, modelEntity: ModelEntity, constraints: JointConstraints?) {
        let jointName = boneNames[index]
        guard let joint = modelEntity.findChild(named: jointName) else { return }
        
        // Get child position (next joint or end effector)
        let childJoint: ModelEntity?
        if index < boneNames.count - 1 {
            childJoint = modelEntity.findChild(named: boneNames[index + 1])
        } else {
            childJoint = modelEntity.findChild(named: boneNames.last ?? "")
        }
        
        guard let child = childJoint else { return }
        
        let jointToChild = simd_normalize(child.position - joint.position)
        let jointToTarget = simd_normalize(target - joint.position)
        
        // Calculate rotation needed
        var rotationAxis = simd_cross(jointToChild, jointToTarget)
        if simd_length(rotationAxis) < 0.001 {
            return  // Already aligned
        }
        
        rotationAxis = simd_normalize(rotationAxis)
        let dotProduct = simd_dot(jointToChild, jointToTarget)
        var angle = acos(max(-1.0, min(1.0, dotProduct))) * chainStepSize
        
        // Apply bend angle constraint if specified
        if let maxBend = constraints?.maxBendAngle {
            angle = min(angle, maxBend * Float.pi / 180.0)  // Convert degrees to radians
        }
        
        // Apply rotation with constraints
        let rotation = simd_quatf(angle: angle, axis: rotationAxis)
        var newTransform = joint.transform
        newTransform.translation = joint.position
        newTransform.rotation = clampRotation(rotation * newTransform.rotation, to: constraints)
        joint.move(to: newTransform, relativeTo: joint.parent, duration: 0)
    }
    
    /// Clamp quaternion rotation to angle constraints
    private func clampRotation(_ quaternion: simd_quatf, to constraints: JointConstraints?) -> simd_quatf {
        guard let constraints = constraints else { return quaternion }
        
        // Extract euler angles from quaternion (simplified clamping)
        let euler = quaternionToEuler(quaternion)
        let clampedEuler = SIMD3<Float>(
            max(constraints.minAngles.x, min(constraints.maxAngles.x, euler.x)),
            max(constraints.minAngles.y, min(constraints.maxAngles.y, euler.y)),
            max(constraints.minAngles.z, min(constraints.maxAngles.z, euler.z))
        ) * Float.pi / 180.0  // Convert degrees to radians
        
        return eulerToQuaternion(clampedEuler)
    }
    
    /// Convert quaternion to Euler angles (ZYX order, in degrees)
    private func quaternionToEuler(_ q: simd_quatf) -> SIMD3<Float> {
        // simd_quatf format: (x, y, z, w) where w is the scalar
        let matrix = simd_matrix4x4(q)
        
        // Simple approximation: get angles from rotation matrix
        let m = matrix.columns
        
        // Pitch
        let sinPitch = m.1.y
        let pitch = asin(max(-1.0, min(1.0, sinPitch))) * 180.0 / Float.pi
        
        // Roll
        let tanRoll = m.2.y / m.2.z
        let roll = atan(tanRoll) * 180.0 / Float.pi
        
        // Yaw
        let tanYaw = -m.1.x / m.1.z
        let yaw = atan(tanYaw) * 180.0 / Float.pi
        
        return [roll, pitch, yaw]
    }
    
    /// Convert Euler angles (in radians) to quaternion
    private func eulerToQuaternion(_ euler: SIMD3<Float>) -> simd_quatf {
        let cy = cos(euler.z * 0.5)
        let sy = sin(euler.z * 0.5)
        let cp = cos(euler.y * 0.5)
        let sp = sin(euler.y * 0.5)
        let cr = cos(euler.x * 0.5)
        let sr = sin(euler.x * 0.5)
        
        let w = cr * cp * cy + sr * sp * sy
        let x = sr * cp * cy - cr * sp * sy
        let y = cr * sp * cy + sr * cp * sy
        let z = cr * cp * sy - sr * sp * cy
        
        return simd_quatf(ix: x, iy: y, iz: z, r: w)
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
