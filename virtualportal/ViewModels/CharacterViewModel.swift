//
//  CharacterViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine
import RealityKit
import simd

/// ViewModel for character control and animation
/// Manages character state and coordinates with PositionController
@MainActor
public class CharacterViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var currentPosition: SIMD3<Float> = .zero
    @Published public var currentRotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
    @Published public var currentScale: Float = 1.0
    @Published public var currentAnimation: String?
    
    // MARK: - Dependencies
    private let positionController = PositionController.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    public init() {
        setupBindings()
    }
    
    private func setupBindings() {
        // Bind to PositionController
        positionController.$currentPosition
            .assign(to: &$currentPosition)
        
        positionController.$currentRotation
            .assign(to: &$currentRotation)
        
        positionController.$currentScale
            .assign(to: &$currentScale)
        
        positionController.$currentAnimation
            .assign(to: &$currentAnimation)
    }
    
    // MARK: - Public Methods
    
    /// Execute a command on the character
    public func executeCommand(_ command: CharacterCommand) async {
        await positionController.execute(command)
    }
    
    /// Parse commands from text
    public func parseCommands(from text: String) -> [CharacterCommand] {
        positionController.parseCommands(from: text)
    }
    
    // Convenience methods for common actions
    public func moveTo(x: Float, y: Float, z: Float) async {
        await executeCommand(.move(x: x, y: y, z: z))
    }
    
    public func moveBy(x: Float, y: Float, z: Float) async {
        await executeCommand(.moveRelative(x: x, y: y, z: z))
    }
    
    public func rotate(yaw: Float, pitch: Float = 0, roll: Float = 0) async {
        await executeCommand(.rotate(yaw: yaw, pitch: pitch, roll: roll))
    }
    
    public func setScale(_ scale: Float) async {
        await executeCommand(.scale(scale))
    }
    
    public func playAnimation(_ name: String, loop: Bool = false) async {
        await executeCommand(.playAnimation(name: name, loop: loop))
    }
    
    public func stopAnimation() async {
        await executeCommand(.stopAnimation)
    }
    
    public func lookAt(x: Float, y: Float, z: Float) async {
        await executeCommand(.lookAt(x: x, y: y, z: z))
    }
    
    public func reset() async {
        await executeCommand(.reset)
    }
    
    public func setBlendShape(name: String, value: Float) async {
        await executeCommand(.blendShape(name: name, value: value))
    }
}
