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
    
    private var cancellables = Set<AnyCancellable>()

    public func setBlendShape(name: String, value: Float) {
        ModelRenderer.shared.setBlendShape(name: name, value: value)
    }
}
