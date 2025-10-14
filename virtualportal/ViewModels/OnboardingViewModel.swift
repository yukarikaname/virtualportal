//
//  OnboardingViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine

/// ViewModel for onboarding flow
/// Manages permission requests and setup steps
@MainActor
public class OnboardingViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var currentStep: Int = 0
    @Published public var cameraPermissionGranted: Bool = false
    @Published public var speechPermissionGranted: Bool = false
    @Published public var isRequestingPermissions: Bool = false
    
    // MARK: - Computed Properties
    public var allPermissionsGranted: Bool {
        cameraPermissionGranted && speechPermissionGranted
    }
    
    public var canContinue: Bool {
        switch currentStep {
        case 1: return allPermissionsGranted
        default: return true
        }
    }
    
    // MARK: - Initialization
    public init() {
        checkExistingPermissions()
    }
    
    // MARK: - Public Methods
    
    /// Check current permission status
    public func checkExistingPermissions() {
        PermissionManager.checkCameraPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.cameraPermissionGranted = granted
            }
        }
        
        PermissionManager.checkSpeechRecognitionPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.speechPermissionGranted = granted
            }
        }
    }
    
    /// Request camera permission
    public func requestCameraPermission() {
        isRequestingPermissions = true
        PermissionManager.requestCameraPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.cameraPermissionGranted = granted
                self?.isRequestingPermissions = false
            }
        }
    }
    
    /// Request speech recognition permission
    public func requestSpeechPermission() {
        isRequestingPermissions = true
        PermissionManager.requestSpeechRecognitionPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.speechPermissionGranted = granted
                self?.isRequestingPermissions = false
            }
        }
    }
    
    /// Request all permissions
    public func requestAllPermissions() {
        requestCameraPermission()
        requestSpeechPermission()
    }
    
    /// Move to next step
    public func nextStep() {
        guard canContinue else { return }
        currentStep += 1
    }
    
    /// Move to previous step
    public func previousStep() {
        guard currentStep > 0 else { return }
        currentStep -= 1
    }
    
    /// Complete onboarding
    public func completeOnboarding(completion: @escaping () -> Void) {
        guard allPermissionsGranted else { return }
        completion()
    }
}
