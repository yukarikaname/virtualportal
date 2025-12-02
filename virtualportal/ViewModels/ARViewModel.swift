//
//  ARViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import SwiftUI
import Combine
import RealityKit
#if os(iOS)
import ARKit
#endif

/// ViewModel for AR scene management
/// Coordinates between View layer and Model layer (CharacterModelController)
@MainActor
public class ARViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var isModelVisible: Bool = false
    @Published public var isModelLoading: Bool = false
    @Published public var modelScale: Double = 1.0
    @Published public var hideControls: Bool = false
    @Published public var thumbnail: UIImage?
    
    // Off-screen indicator
    @Published public var isIndicatorVisible: Bool = false
    @Published public var indicatorPosition: CGPoint = .zero
    @Published public var indicatorAngle: Angle = .zero
    
    // MARK: - Dependencies
    private let characterController = CharacterModelController.shared
    //    private let positionController = PositionController.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    public init() {
        setupBindings()
        loadUserSettings()
    }
    
    private func setupBindings() {
        // Observe character controller state
        characterController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    private func loadUserSettings() {
        modelScale = UserDefaults.standard.double(forKey: "modelScale")
        if modelScale == 0 { modelScale = 1.0 }
    }
    
    // MARK: - Public Methods
    
    /// Check if model is placed in the scene
    public var hasPlacedModel: Bool {
        characterController.hasPlacedModel
    }
    
    /// Get current model entity
    public var modelEntity: ModelEntity? {
        characterController.modelEntity
    }
    
    /// Update off-screen indicator state
    public func updateIndicator(visible: Bool, position: CGPoint, angle: Double) {
        isIndicatorVisible = visible
        indicatorPosition = position
        indicatorAngle = Angle(degrees: angle)
    }
    
    /// Reset AR session
    public func resetARSession() {
        // Delegated to CharacterModelController via NotificationCenter
        NotificationCenter.default.post(name: Notification.Name("virtualportal.arConfigurationChanged"), object: nil)
    }
    
    /// Capture photo
    public func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        // Trigger a photo capture via NotificationCenter; the View handles snapshotting
        NotificationCenter.default.post(name: Notification.Name("virtualportal.cameraCaptureRequested"), object: nil)
    }
}
