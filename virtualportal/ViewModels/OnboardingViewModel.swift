//
//  OnboardingViewModel.swift
//  virtualportal
//
//  Created by Yukari Kaname on 11/8/25.
//

import Foundation
import Combine
import SwiftUI

/// ViewModel for onboarding flow
/// Manages permission requests and setup steps
@MainActor
public class OnboardingViewModel: ObservableObject {
    
    // MARK: - Published Properties
    @Published public var currentStep: Int = 0

    // Previously delegated to PermissionViewModel; onboarding no longer gates on permissions

    /// Move to next step
    public func nextStep() {
        currentStep += 1
    }
    
    /// Move to previous step
    public func previousStep() {
        guard currentStep > 0 else { return }
        currentStep -= 1
    }
    
    /// Complete onboarding
    public func completeOnboarding(completion: @escaping () -> Void) {
        completion()
    }

    // MARK: - Initialization
    public init() {
        // No-op: permissions are handled elsewhere at runtime
    }
}
